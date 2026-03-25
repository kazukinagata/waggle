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

## Rules

- **Issuer is preserved** — it tracks who originated the task, not the current assignee.
- **Assignees is set to exactly 1 person** — the recipient. If multiple people are needed, suggest splitting the task.
- These resets apply regardless of the task's current state. Even if the task previously had an AI executor, assigning to another person resets to `human`.
