---
name: managing-tasks
description: >
  Creates, updates, deletes, and queries tasks in the configured data source.
  Handles task creation with required confirmations, state transitions,
  "next task" recommendations, and personal task dashboard.
  Use this skill for ANY task-related request — create, update, delete,
  query, list, filter by status/priority/assignee, mark done, block, assign
  to self, change priority, view personal dashboards, or ask "what's next".
  Also handles task dependencies and links: block, unblock, blocked by,
  blocking, dependency/dependencies, parent task, subtask, child task,
  link tasks, relation, connect tasks. Also scoped queries such as
  "tasks for <store/project>" or "filter tasks by store/project".
  If the user mentions tasks in any way, use this skill.
  Invoke this skill for any Tasks DB write — do not call
  `notion-create-pages`, `notion-update-page`, or `notion-update-relation`
  on task pages directly, even for single-field edits. Direct writes are
  blocked by a PreToolUse hook and skip quality gates (AC/EP rubric,
  executor invariants, Acknowledged At auto-set, subtask cascading).
user-invocable: true
---

# Waggle — Task Management

You are managing tasks in the configured data source. Use the provider-specific tools for all data operations.

## Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
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

For the full task creation flow — assignee resolution, required confirmations, executor choice, questioning flow, pre-creation checklist, and status auto-determination — follow `references/task-creation-flow.md` in this directory.

Before starting the flow, invoke the `loading-custom-instructions` skill with key `task-creation` to populate `custom_task_creation_instructions`. If the returned value is non-null, the task-creation flow uses it as authoritative guidance for business-logic-dependent defaults (Tags, Priority, Assignee selection, AC/Execution Plan phrasing) on top of the standard questioning. If null, the flow proceeds with the normal defaults. See `references/task-creation-flow.md` Step 0.

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

## Subtask Status Cascading

After any task status change or subtask creation, check and apply automatic status cascading.

### Trigger Conditions

Cascading runs when:
1. A task's Status is updated AND the task has a non-null `parentTask`
2. A new subtask is created (has `parentTask` set)
3. A task's `parentTask` field is set or cleared

### Cascading Rules

**Rule A — All subtasks Done → Parent auto-transitions to Done:**
1. After updating a subtask to `Done`, fetch all sibling tasks (tasks sharing the same `parentTask`)
2. If every sibling's Status is `Done`, update the parent's Status to `Done`
3. Append to parent's Context: `[Auto] Status set to Done — all subtasks completed`

**Rule B — Subtask added to Done parent → Parent reverts to In Progress:**
1. When creating a subtask whose parent's current Status is `Done`, update parent Status to `In Progress`
2. Append to parent's Context: `[Auto] Status reverted to In Progress — new subtask added`

**Rule C — Subtask re-opened → Parent reverts if it was Done:**
1. After updating a subtask from `Done` to any other status, check the parent's Status
2. If parent is `Done`, update parent to `In Progress`
3. Append to parent's Context: `[Auto] Status reverted to In Progress — subtask re-opened`

### Cascading Pseudocode

```
After updating task T's status:
  1. If T.parentTask is null → no cascading, return
  2. Fetch parent P = get_task(T.parentTask)
  3. If T.status == "Done":
     a. Fetch all subtasks S = query_tasks(parentTask == P.id)
     b. If ALL tasks in S have status "Done" → update P.status = "Done", log in P.context
  4. Else if T.status != "Done" AND P.status == "Done":
     → update P.status = "In Progress", log in P.context
  5. Push updated data to view server
```

These auto-transitions are system-initiated and bypass normal validation (no user confirmation needed).

## Auto-Acknowledge on Task Interaction

When the user updates a specific task (status change, field edit, etc.) and the task's `Assignee` includes `current_user.id`: if `Acknowledged At` exists in the schema and is null, set it to the current ISO 8601 timestamp as part of the update. Silent operation — no user prompt.

## After Any Task Operation

After creating, updating, or deleting tasks, push fresh data to the view server as described in the active provider's SKILL.md (Pushing Data to View Server section).

## My Tasks View

When the user asks "my tasks", "assigned to me", "show my tasks", or similar:

### Step 1: Fetch My Tasks

Use the active provider SKILL.md's "Querying Tasks" section to fetch tasks filtered by Assignee = `current_user.id`. The provider determines the optimal query path.

### Step 1b: Auto-Acknowledge

After fetching, check each returned task: if the `Acknowledged At` field exists in the schema and is null/empty, update the task to set `Acknowledged At` to the current ISO 8601 timestamp. This is a silent background operation — do not prompt the user. Batch multiple updates if possible.

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
