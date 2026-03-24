---
name: waggle-protocol
description: >
  Waggle Protocol v1 specification. Defines the 14 core fields, 11 extended
  fields, task state machine, dispatch readiness checks, stall detection
  formula, and execution environments. Use this skill when you need to
  understand the waggle protocol, check field definitions, verify state
  transitions, or reference the stall detection constants. Trigger on:
  "protocol spec", "waggle spec", "field definitions", "state machine",
  "stall detection", "task schema", "core fields".
user-invocable: true
---

# Waggle Protocol v1

## Overview

Waggle Protocol is a specification for independent AI agent instances to coordinate asynchronously through a shared task board.

Agents discover tasks, claim them, execute, and hand off results. The backing data store is irrelevant — any storage that implements this specification's fields and state transitions is a Waggle-compatible task board.

## Core Fields

Every Waggle-compatible task board MUST support these 14 fields:

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
| Dispatched At | datetime | Timestamp when the task was dispatched. Used for stall detection |
| Agent Output | rich_text | Execution result written by the agent on completion |
| Error Message | rich_text | Written on failure only |

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
| Assignees | person[] | Assigned users |
| Complexity Score | number | Fibonacci-like score (1-13) for stall detection and velocity |
| Backlog Order | number | Ordering within the backlog |

## State Machine

```
Backlog → Ready → In Progress → In Review → Done
                       ↓
                    Blocked
```

### Transition Conditions

| From | To | Condition |
|---|---|---|
| Backlog | Ready | Description, Acceptance Criteria, Assignees, and Execution Plan are all non-empty. Complexity Score is calculated if scrum is enabled |
| Ready | In Progress | Executor is assigned. Dispatched At is recorded |
| In Progress | In Review | Requires Review = true. Agent Output is recorded |
| In Progress | Done | Requires Review = false. Agent Output is recorded |
| In Progress | Blocked | Error occurred or dependency unresolved. Error Message is recorded |
| In Review | Done | Review approved |
| In Review | In Progress | Changes requested |
| Any | Backlog | Deprioritize / re-triage |

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

If any check fails, the orchestrator MUST NOT dispatch. Instead, it should prompt the user to fill the missing information.

## Stall Detection

Agents may get stuck. Waggle defines a stall detection formula:

```
stall_threshold = complexity_score * stallThresholdMultiplier hours
default_threshold = stallDefaultHours

Constants:
  stallThresholdMultiplier = 4
  stallDefaultHours = 24

A task is stalled if:
  (now - dispatched_at) > stall_threshold   (when complexity_score is set)
  (now - dispatched_at) > default_threshold  (when complexity_score is not set)
```

Stalled tasks SHOULD be flagged in status reports but are NOT automatically transitioned.

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
| Cowork | `CLAUDE_CODE_IS_COWORK=1` | Scheduled Tasks |
| Claude Desktop | `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | Scheduled Tasks |
| CLI | `CLAUDE_CODE_ENTRYPOINT=cli` (or unset) | tmux panes |

All environments support single-task execution in the current session.

## Versioning

This is Waggle Protocol **v1**. Breaking changes to Core fields or the state machine require a major version bump.
