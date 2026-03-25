---
name: managing-tasks
description: >
  Creates, updates, deletes, and queries tasks in the configured data source.
  Handles task creation with required confirmations, state transitions,
  "next task" recommendations, and personal task dashboard.
  Use this skill for ANY task-related request — creating, updating, deleting,
  querying, listing, filtering by status/priority/assignee, marking done,
  blocking, assigning, changing priority, viewing personal dashboards, or
  asking "what's next". If the user mentions tasks in any way, use this skill.
  Triggers on: "add task", "create task", "update task", "done", "change status",
  "list tasks", "what's next", "next task", "block", "assign", "prioritize",
  "show tasks", "get tasks", "fetch tasks", "my tasks", "assigned to me",
  "show my tasks", "what are my tasks".
user-invocable: true
---

# Waggle — Task Management

You are managing tasks in the configured data source. Use the provider-specific tools for all data operations.

## Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Schema and State Transitions

For the full task schema (15 Core + 8 Extended fields) and state transition rules including validation, see `references/schema-and-transitions.md` in this directory. Always run validation before status changes — never skip it.

## "Next Task" Logic

When the user asks "what should I do next?" or "next task":

1. Query tasks where Status = "Ready" using the active provider's query tools
2. Filter out tasks where `Blocked By` contains any non-Done task (unresolved dependencies)
3. Sort by Priority: Urgent > High > Medium > Low
4. Within same priority, sort by Due Date (earliest first)
5. Present the top task with its full context

## Task Creation

For the full task creation flow — assignees resolution, required confirmations, executor choice, questioning flow, pre-creation checklist, and status auto-determination — follow `references/task-creation-flow.md` in this directory.

## Human → Agent Re-assignment

When the user wants to change an Executor=human task to an agent:
- AskUserQuestion: "Execute '{task title}' with an agent? [cli / claude-desktop / cowork / keep human]"
- When cli, claude-desktop, or cowork is selected:
  1. Confirm Working Directory (required)
  2. Confirm Branch (optional)
  3. Update Executor, Working Directory, Branch
  4. Push data to the View Server

## Bulk Operations

For requests like "show me all blocked tasks" or "mark all Done tasks as archived":
1. Query tasks using the active provider's query tools with appropriate filters
2. Present results to user for confirmation
3. Execute updates in sequence using the provider's update tools

## After Any Task Operation

After creating, updating, or deleting tasks, push fresh data to the view server as described in the active provider's SKILL.md (Pushing Data to View Server section).

## My Tasks View

When the user asks "my tasks", "assigned to me", "show my tasks", or similar:

### Step 1: Fetch My Tasks

Use the active provider SKILL.md's "Querying Tasks" section to fetch tasks filtered by Assignee = `current_user.id`. The provider determines the optimal query path.

### Step 2: Display by Status Group

Group tasks by Status and display in the following order:

#### In Progress
For each task, show:
- Title, Priority
- Executor / Session Reference (display as-is if present: whether tmux session name or scheduled:xxx)
- `Dispatched At` (if set)

#### Ready
Group by `Executor`:
- **cli**: ready for autonomous execution in Terminal CLI
- **claude-desktop**: ready for Claude Desktop Scheduled Task
- **cowork**: ready for Cowork Scheduled Task
- **human**: waiting for manual action

#### Blocked
For each task, show the blocking task titles (from `Blocked By` relation).

#### In Review
List tasks awaiting review.

#### Backlog
List titles only (collapsed to keep output concise).

### Step 3: Next Actions

After displaying the task list, suggest next actions:

```
Next actions:
- Execute tasks: /executing-tasks
- Manage tasks (reassign, change status, etc.): /managing-tasks
- Delegate tasks: /delegating-tasks
```
