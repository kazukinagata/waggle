---
name: assigning-to-others
description: >
  Shared logic for resetting fields when assigning a task to another person.
  Enforces standard field constraints so the recipient can configure their own
  execution environment. Called by managing-tasks, delegating-tasks, and
  ingesting-messages.
user-invocable: false
---

# Waggle — Assign-to-Others Field Reset

When assigning a task to someone other than the current user, apply the following field constraints. The rationale is that the recipient's execution environment (filesystem, git, agent session) is unknown to the delegator.

## Required Field Resets

| Field | Value | Reason |
|---|---|---|
| `Executor` | `human` | The recipient decides how to execute |
| `Working Directory` | blank | The recipient's filesystem is unknown |
| `Branch` | blank | The recipient's git environment is unknown |
| `Session Reference` | blank | The recipient's agent will record this |
| `Dispatched At` | blank | The recipient's agent will record this |
| `Requires Review` | unchecked | The recipient decides |
| `Acknowledged At` | blank | The new assignee has not seen the task yet |

## Rules

- **Issuer is preserved** — it tracks who originated the task, not the current assignee.
- **Assignee is set to exactly 1 person** — the recipient. NEVER set multiple people in Assignee, even if the user says "assign to team X" or "assign to everyone". If the user requests a team or group assignment, ask which specific member to assign, or suggest splitting the task into per-member subtasks.
- These resets apply regardless of the task's current state. Even if the task previously had an AI executor, assigning to another person resets to `human`.

## Pre-assignment Quality Check (v2.8.0+, default-on, live cache-aware)

Before applying the field resets, invoke the `reviewing-quality` skill in **live, cache-aware** mode for the task. This catches tasks that bypassed the quality gates (Notion UI direct edits, legacy tasks) before they reach a new assignee.

Mode behavior:
- Cache hit + PASS → proceed with the resets silently (no LLM wait, the 99% case for tasks created through the v2.8.0 pipeline).
- Cache hit + NEEDS_REFINEMENT / REJECT → surface the cached gaps + suggested fixes to the user; ask `[Refine via /planning-tasks] [Assign anyway]`. On "Refine", abort the assignment so the user can plan first. On "Assign anyway", proceed.
- Cache miss → invoke the Reviewer live (~10–20s). Assignment is rare enough that this latency is acceptable. Branch on the live verdict the same way.

Worthiness:* tagged tasks skip the Reviewer per protocol; their `worthiness:calendar-like` / `worthiness:info-only` classification is intentional, and re-evaluating them at assignment would be noise.

The `[Assign anyway]` override is always available. This gate is advisory, not enforcing — but unlike `executing-tasks` dispatch, it IS willing to pay the live Reviewer cost because delegation is the bypass-catch chokepoint.
