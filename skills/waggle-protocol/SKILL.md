---
name: waggle-protocol
description: >
  Waggle Protocol v1 specification. Defines the 15 core fields, 9 extended
  fields, task state machine, dispatch readiness checks, and execution
  environments. Use this skill when you need to understand the waggle
  protocol, check field definitions, or verify state transitions. Trigger on:
  "protocol spec", "waggle spec", "field definitions", "state machine",
  "task schema", "core fields".
user-invocable: true
---

# Waggle Protocol v1

## Overview

Waggle Protocol is a specification for independent AI agent instances to coordinate asynchronously through a shared task board.

Agents discover tasks, claim them, execute, and hand off results. The backing data store is irrelevant — any storage that implements this specification's fields and state transitions is a Waggle-compatible task board.

## Core Fields

Every Waggle-compatible task board MUST support these 16 fields:

| Field | Type | Description |
|---|---|---|
| Title | text | Task name |
| Description | rich_text | What the task should accomplish |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | enum | See State Machine below |
| Priority | enum | Urgent / High / Medium / Low |
| Executor | enum | cli / claude-desktop / cowork / human (extensible) |
| Blocked By | relation[] | Dependencies — other task IDs that must be Done before this task is actionable |
| Requires Review | boolean | If true, task must pass In Review before Done |
| Execution Plan | rich_text | Step-by-step plan written before dispatch. Write-once |
| Working Directory | text | Absolute path for agent execution |
| Session Reference | text | Runtime session identifier (tmux session name, Scheduled Task ID, etc.) |
| Dispatched At | datetime | Timestamp when the task was dispatched |
| Agent Output | rich_text | Execution result written by the agent on completion |
| Error Message | rich_text | Written on failure only |
| Issuer | provider-managed | Who created/initiated this task. **Auto-populated by the active provider on create. Read-only after creation. Skills MUST NOT include Issuer in create payloads.** See "Issuer Auto-Populate Contract" below. v2.8.1+ |
| Quality Verdict | rich_text | Cached Reviewer verdict (PASS/NEEDS_REFINEMENT/REJECT). See Quality Spec below. v2.8.0+ |

### Extended Fields (optional)

Providers MAY support these additional fields. Skills degrade gracefully if absent.

| Field | Type | Description |
|---|---|---|
| Context | rich_text | Background info, constraints, delegation history |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Due Date | date | ISO 8601 format |
| Tags | multi_select | Free-form tags |
| Parent Task | relation | Parent task ID (subtask relationship) |
| Project | text | Project grouping |
| Team | text | Team assignment |
| Assignee | person[] | Assigned users |

## Issuer Auto-Populate Contract (v2.8.1+)

The `Issuer` core field is **always** populated by the active provider during task creation. Skills (`managing-tasks`, `ingesting-messages`, etc.) MUST NOT pass an Issuer value when invoking the provider's Create Task operation.

### Why

Prior to v2.8.1, skills explicitly set `Issuer = current_user`. Field telemetry showed ~27% of tasks ended up with empty Issuer due to multiple failure paths: scheduled tasks where `current_user` could not be resolved, third-party automations writing directly to the data store, intake flows omitting Issuer in the create payload, and direct edits in the provider UI. Centralizing Issuer population in each provider eliminates every one of those paths.

### Per-provider implementation

| Provider | Mechanism |
|---|---|
| **Notion** | `Issuer` column is type `created_by`. Notion auto-populates with the API token's owning user on insert. Read-only via API. |
| **SQLite** | `Issuer` column is `TEXT`. The provider's Create Task INSERT template substitutes `${current_user.id}` literally; the caller invokes the template without supplying Issuer. |
| **Turso** | Same as SQLite. |

### Provider preconditions

Providers using template substitution (SQLite, Turso) MUST halt with an error before executing Create Task if `current_user.id` resolves to the unresolved-identity sentinel `"unknown"`. This enforces "no anonymous tasks" — every Issuer in the data store points to a real identity. (v2.7.x also halted on the literal `"local"`; v2.8.1 removed `"local"` from the identity chain entirely — providers now derive `id` from `$WAGGLE_USER_ID` → `$USER` → `"unknown"`, so the only remaining anonymous case is `"unknown"`.)

The Notion provider does not need this check because Notion's API binds `created_by` to the API token owner, which is always a real user.

### Write-once enforcement

Notion's `created_by` is read-only after creation. SQLite/Turso providers MUST NOT include `issuer` in their Update Task templates. Delegation (`assigning-to-others` / `delegating-tasks`) updates `Assignee` but never touches `Issuer`.

### Filtering by Issuer

Notion's API filters `created_by` columns using the `created_by:{contains: <user_id>}` operator (this is distinct from the `people` operator used for `person` columns — the operator key matches the column type). The notion-provider filter recipes in v2.8.1 use this syntax.

SQLite/Turso providers filter via `WHERE issuer = '<user_id>'` for exact match (the column is now a single-value `TEXT`, not a JSON array, so the v2.7.x `LIKE '%<user_id>%'` pattern is unnecessary).

## Subtask Hierarchy

Waggle supports a strict 2-level task hierarchy via the `Parent Task` field.

### Constraints

- **2-level limit**: A subtask (task with non-null `parentTask`) MUST NOT have children of its own. Implementations MUST reject attempts to create a 3rd level.
- **No circular references**: A task cannot reference itself as its parent.

### Auto-Cascading Transitions

When all subtasks of a parent reach `Done`, the parent auto-transitions to `Done`. When a subtask is added to or re-opened on a `Done` parent, the parent reverts to `In Progress`. These are system-initiated transitions that bypass normal validation.

### Execution Independence

Subtasks are eligible for execution regardless of their parent task's status. The hierarchy is for progress tracking, not execution gating.

## State Machine

```
Backlog → Ready → In Progress → In Review → Done
                       ↓
                    Blocked

Any → Cancelled
```

### Transition Conditions

| From | To | Condition |
|---|---|---|
| Backlog | Ready | Description, Acceptance Criteria, Assignee, and Execution Plan are all non-empty AND Rubric (Layer 1) passes AND Quality Verdict cache satisfies dispatch readiness (see Dispatch Readiness Check + Quality Spec below) |
| Ready | In Progress | Executor is assigned. Dispatched At is recorded. Dispatch Readiness Check passes |
| In Progress | In Review | Requires Review = true. Agent Output is recorded |
| In Progress | Done | Requires Review = false. Agent Output is recorded |
| In Progress | Blocked | Error occurred or dependency unresolved. Error Message is recorded |
| In Review | Done | Review approved |
| In Review | In Progress | Changes requested |
| Any | Backlog | Deprioritize / re-triage |
| Any | Cancelled | Task abandoned or no longer relevant |

### Invalid Transitions

All transitions not listed above are invalid. Implementations MUST reject them.

## Dispatch Readiness Check

Before transitioning a task from Ready → In Progress, the orchestrator MUST verify:

| Field | Check |
|---|---|
| Description | Non-empty, at least ~50 tokens |
| Acceptance Criteria | Non-empty, contains testable conditions |
| Execution Plan | Non-empty |
| Working Directory | Non-empty AND the directory exists on the filesystem |
| Quality Verdict (v2.8.0+) | Cache PASS preferred; cache miss / fail surfaces 2-choice prompt. Live Reviewer invocation is forbidden at dispatch (hot path) |

If any check fails, the orchestrator MUST NOT dispatch. Instead, it should prompt the user to fill the missing information.

## Quality Spec (v2.8.0+)

Waggle v2.8.0 introduces a 3-layer quality gate system to ensure agent-reproducible task specs.

### Layer 0: Task-Worthiness Advisory

Applied at intake (`ingesting-messages` Phase A) only. Classifies whether an incoming item is task-shaped.

| Verdict | Meaning |
|---|---|
| `task` | Actionable work; proceeds to Layer 1/2 |
| `calendar-like` | Recurring meeting / pure attendance; should not be a task. Advisory only |
| `info-only` | FYI / handled / single-fact message; should not be a task. Advisory only |

**Waggle never silently discards user-created items.** Layer 0 surfaces a suggestion in the intake confirmation table; the user always has the final say via `[Create as task] / [Convert to note] / [Discard]`. Items chosen as `[Create as task]` are tagged `worthiness:calendar-like` or `worthiness:info-only` and skip Layer 1/2 for the rest of their lifecycle.

### Layer 1: Rubric (deterministic)

Applied at every status transition into Ready or beyond. No LLM involvement.

**AC rules** (each failing rule contributes to verdict):

| Rule | Check |
|---|---|
| R-AC1 | Each criterion contains ≥1 verifiable indicator (command, file path, numeric threshold + unit, observable verb, URL, code token) |
| R-AC2 | Criteria are not just a verb-form restatement of the Title (no "echo-of-title") |
| R-AC3 | Criteria are grounded in the original task description or are explicitly prefixed `[INFERRED]` |
| R-AC4 | No reserved placeholder remains (`[DRAFT-AC]`, `[NEEDS-REFINE]`) |

**EP rules**:

| Rule | Check |
|---|---|
| R-EP1 | 3–7 numbered steps. <3 too thin; >7 → suggest split |
| R-EP2 | Each step averages ≥30 characters and contains an action verb + target + outcome |
| R-EP3 | EP overall contains ≥1 concrete artifact (file path, command, branch, URL, PR number, etc.) |
| R-EP4 | When `Executor` is AI (cli / claude-code / claude-desktop / cowork), `Working Directory` is set and the EP references paths consistent with it |

### Layer 2: Intent Reproducibility Check (LLM)

The `task-quality-reviewer-agent` evaluates a task spec along 5 axes from the perspective of "a new colleague handed only this spec, with access to the team's tools — can they reproduce the issuer's intent?":

| Axis | Question |
|---|---|
| Goal clarity | Can the desired end state be described in one sentence after reading? |
| Boundary clarity | Is scope clear; where does the task stop? |
| Verifiability | How do I know I'm done? Is there a checkable signal? |
| Reproducibility | Are tools/paths/commands/datasets named? |
| Hidden context | Is there organizational knowledge the issuer assumed but didn't write down? |

Verdict (rules applied in order — first match wins):
- `REJECT` — ≥1 axis ✗ (fundamental rewrite required)
- `NEEDS_REFINEMENT` — ≥1 axis △ and no ✗ (specific suggested fixes can elevate to PASS; the number of △ axes is informational only)
- `PASS` — all 5 axes ◯

### Reserved Placeholder Prefixes

Exactly 2 prefixes are reserved at the protocol level:

| Prefix | Meaning |
|---|---|
| `[DRAFT-AC]` / `[DRAFT-EP]` | Field is intentionally an empty stub; refinement pending |
| `[NEEDS-REFINE]` | Reviewer returned NEEDS_REFINEMENT or REJECT; field needs work before promotion |

Skills MUST NOT introduce additional reserved prefixes. Other tags (e.g., `worthiness:*`) live on the `Tags` field, not as title or AC prefixes.

### Quality Verdict Cache Format (v1)

The `Quality Verdict` core field stores at most one line in the format:

```
{verdict} hash=<sha256(Title|Description|AC|EP)[:8]> @<iso8601> v1 [suppressed-until=<iso8601>]
```

- `verdict` ∈ `PASS`, `NEEDS_REFINEMENT`, `REJECT`
- `hash` is a content fingerprint over the first 8 hex chars of SHA-256 of `Title|Description|AC|EP` (pipe-delimited). Any edit to those fields invalidates the cache automatically.
- `suppressed-until` (optional) freezes re-review for 7 days after 2 consecutive same-axis failures (anti-grinding guard).
- `v1` is the format version. Future versions remain parse-compatible.

Live Reviewer invocation is allowed at: `planning-tasks`, `ingesting-messages` Phase A.5, `running-daily-tasks` Step 2.6, `delegating-tasks` (cache miss), `monitoring-tasks --deep`.

Live Reviewer invocation is **forbidden** at: `executing-tasks` dispatch (cache-only), `managing-tasks` pre-Ready (cache-only). These are hot paths.

### Calibration Requirement

Before a Waggle release that ships the Reviewer agent or Layer 0 classifier, implementations MUST measure agreement against hand-labeled samples. Recommended bar: ≥80% on 30 hand-labeled tasks. Below threshold, the affected layer ships disabled.

## Provider Interface

A Waggle provider is any backend that implements the following operations:

| Operation | Description |
|---|---|
| `create_task(fields)` | Create a new task with the given fields |
| `update_task(id, fields)` | Update one or more fields on an existing task |
| `get_task(id)` | Retrieve a single task by ID |
| `query_tasks(filters, sorts)` | Query tasks with filters and sort ordering |
| `delete_task(id)` | Delete a task |
| `validate_schema()` | Verify all Core fields exist in the backing store |
| `auto_repair_schema()` | Create any missing Core fields with sensible defaults |

### Provider Registration

Providers are delivered as separate plugins (e.g., waggle-notion, waggle-sqlite, waggle-turso). Detection happens via `<available_skills>` on Cowork or `installed_plugins.json` on CLI/Desktop. See the detecting-provider skill for the detection algorithm.

## Execution Environments

| Environment | Detection | Parallel Method |
|---|---|---|
| Cowork | system prompt self-identifies as Cowork, OR `mcp__cowork__*` tools available, OR `CLAUDE_CODE_IS_COWORK=1` (legacy) | Scheduled Tasks |
| Claude Desktop | `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | Scheduled Tasks |
| CLI | `CLAUDE_CODE_ENTRYPOINT=cli` (or unset) | tmux panes |

See `provider-contract/references/environment-detection.md` for the full multi-signal Cowork detection logic.

All environments support single-task execution in the current session.

## Versioning

This is Waggle Protocol **v1**. Breaking changes to Core fields or the state machine require a major version bump.
