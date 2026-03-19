---
name: managing-tasks
description: >
  Creates, updates, deletes, and queries tasks in the configured data source.
  Handles task creation with required confirmations, state transitions,
  complexity scoring, "next task" recommendations, and personal task dashboard.
  Triggers on: "add task", "create task", "update task", "done", "change status",
  "list tasks", "what's next", "next task", "block", "assign", "prioritize",
  "show tasks", "get tasks", "fetch tasks", "my tasks", "assigned to me",
  "show my tasks", "what are my tasks",
  "タスク追加", "タスク作成", "タスク更新", "完了", "ステータス変更",
  "タスク一覧", "タスクを見せて", "次のタスク", "自分のタスク", "私のタスク",
  "担当タスク", "タスク取得".
  Use this skill for ANY task-related query including listing tasks for specific
  people or filtering by status/priority.
---

# Agentic Tasks — Task Management

You are managing tasks in the configured data source. Use the provider-specific tools for all data operations.

## Provider Detection (once per session)

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider`. Skip if already determined in this conversation.

After provider detection completes, you MUST read `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` if you have not already done so. This file defines the Query Path Detection logic — do NOT query tasks using MCP tools directly without first determining the correct query path from the provider SKILL.md.

After provider detection, also check the config for sprint fields (if present):
- `sprintsDatabaseId` (optional — present only if scrum is enabled)
- `maxConcurrentAgents` (optional — default 3 if absent)

## Schema: Property Name → Notion Type

### Core Fields (required — verify existence at session start)

| Property | Type | Notes |
|---|---|---|
| Title | title | Task name |
| Description | rich_text | Orchestrator-written detail |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | select | Backlog / Ready / In Progress / In Review / Done / Blocked |
| Blocked By | relation | Self-relation (dependency). Empty or all blockers Done = actionable |
| Priority | select | Urgent / High / Medium / Low |
| Executor | select | claude-desktop / cli / human |
| Requires Review | checkbox | On → must pass In Review. Off → can go directly to Done |
| Execution Plan | rich_text | Orchestrator's plan written before dispatch. write-once |
| Working Directory | rich_text | Absolute path to the working directory |
| Session Reference | rich_text | Written after dispatch: tmux session name / Scheduled task ID |
| Dispatched At | date | Dispatch timestamp. Used for timeout detection |
| Agent Output | rich_text | Execution result |
| Error Message | rich_text | Written on failure only. Query with "Error Message is not empty" |

### Extended Fields (optional — graceful degradation if absent)

| Property | Type | Notes |
|---|---|---|
| Context | rich_text | Background info, constraints |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Due Date | date | ISO format |
| Tags | multi_select | Free tags |
| Parent Task | relation | Self-relation (hierarchy) |
| Assignees | people | Human executor assignment |
| Branch | rich_text | Git branch name (e.g. feature/task-slug). Leave blank to work on the current branch |
| Sprint | relation | → Sprints DB (batch assignment; available after setting-up-scrum) |
| Complexity Score | number | Auto-calculated by orchestrator; written when promoting Backlog → Ready |
| Backlog Order | number | Backlog position (lower = higher priority). Agent-suggested, human-overridable |

## State Transition Rules

Valid transitions:
- Backlog → Ready (when description + acceptance criteria + Assignees are filled; also calculate Complexity Score if absent)
  - If Execution Plan is empty when promoting to Ready, warn the user and ask them to provide one
    before proceeding. Do not promote to Ready with an empty Execution Plan.
- Ready → In Progress (when dispatched to executor)
- In Progress → In Review (when `Requires Review` is checked and work is done)
- In Progress → Done (when `Requires Review` is unchecked and work is done)
- In Progress → Blocked (when blocked by another task or error)
- In Review → Done (when review approved)
- In Review → In Progress (when changes requested)
- Any → Backlog (deprioritize)

**When `Requires Review` is Off**, skip In Review and transition directly to Done.
**When writing errors**, set Status to Blocked and write the error message in `Error Message` (not in Agent Output).

### Backlog → Ready: Complexity Score Calculation

When promoting a task from Backlog to Ready, if `Complexity Score` field exists and is empty, calculate and write it:

| Factor | Points |
|---|---|
| Acceptance Criteria lines | × 2 |
| Every 200 tokens in Description | +1 |
| Each level of Blocked By dependency depth | +2 |
| Reference similar past task cycle time (from Agent Output) | adjust ±1-3 |

Round to nearest integer. Typical range: 1–13 (Fibonacci-like: 1, 2, 3, 5, 8, 13).
Write the result to the `Complexity Score` field via the provider's update tool.

## "Next Task" Logic

When the user asks "what should I do next?" or "next task":

**If `sprintsDatabaseId` is in config and an Active sprint exists:**
1. Fetch tasks: Sprint = ActiveSprint AND Status = "Ready" AND (Blocked By is empty or all Blocked By tasks are Done)
2. Sort by: Backlog Order (asc) → Priority (Urgent > High > Medium > Low) → Complexity Score (desc)
3. Count tasks with Status = "In Progress" in the sprint (running agents)
4. If running count >= `maxConcurrentAgents`: report "Currently <N> agents are running (limit: <M>). Wait for completion or increase the limit."
5. If Ready = 0: "No Ready tasks in the sprint. Move tasks from Backlog?"
6. Present the top Ready task

**If no Active sprint (or scrum not set up):**
1. Query tasks where Status = "Ready" using the active provider's query tools
2. Filter out tasks where `Blocked By` contains any non-Done task (unresolved dependencies)
3. Sort by Priority: Urgent > High > Medium > Low
4. Within same priority, sort by Due Date (earliest first)
5. Present the top task with its full context

## Task Creation Best Practices

### Assignees and Identity Resolution

**Assignees is always exactly 1 person** (skill-level rule). If multiple people are needed, suggest splitting the task.

**When the task is for the user themselves:**
- When the user explicitly says "my" or "for me":
  1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` → `active_provider`.
  2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` → `current_user`.
  3. Automatically set `current_user` in `Assignees` (no confirmation needed).

**When assigning to another member:**
- When the user specifies another member's name:
  1. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` → also retrieve `org_members`.
  2. Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve the member ID.
  3. If multiple candidates match, confirm with AskUserQuestion.
  4. Only ask via AskUserQuestion if the member cannot be found.
  5. Force-apply the following fields (constraints when assigning to others):

| Field | Value | Reason |
|---|---|---|
| `Executor` | always `human` | The assignee decides how to execute |
| `Working Directory` | blank | The assignee's filesystem is unknown |
| `Branch` | blank | The assignee's git environment is unknown |
| `Session Reference` | blank | The assignee's agent will record this |
| `Dispatched At` | blank | The assignee's agent will record this |
| `Requires Review` | unchecked | The assignee decides |

### Required Confirmations (no guessing or omitting)

Always confirm the following fields with AskUserQuestion unless the user has explicitly stated them.
Do NOT infer and commit to values from the task description.

| Field | Reason |
|---|---|
| Executor | Execution method varies entirely by executor type (cli / claude-desktop / human) |
| Priority | Urgency depends on the user's current context |
| Working Directory | Wrong path directly causes agent execution errors |
| Sprint (if Active sprint exists) | "Should this task go into the sprint or the backlog?" |

### How to Choose Executor

Never decide the Executor on your own.
Present options and recommended reasons to the user and let them decide.

| Executor | Best for |
|---|---|
| `cli` | Code implementation, research, documentation, script execution via Terminal CLI |
| `claude-desktop` | Tasks dispatched as Scheduled Tasks in Claude Desktop |
| `human` | Tasks requiring human judgment, relationships, or direct interaction |

In AskUserQuestion, include a description with each option explaining why it is recommended.

### Environment-Specific Recommendations

- When `execution_environment = "claude-desktop"`: Recommend `claude-desktop` for AI-executed tasks.
  `cli` is also selectable, but inform the user that a separate Terminal CLI environment is required.
- When `execution_environment = "cli"`: Recommend `cli` for AI-executed tasks.
  `claude-desktop` is also selectable, but inform the user that a Claude Desktop environment is required.

### Branch (git worktree support)

For tasks with Executor=claude-code where the target is a git repository:
- Suggest setting the Branch field (not mandatory)
- Default candidate: `feature/<task-title-slug>`
- If set, executing-tasks can create an isolated environment via `git worktree add`
- If left blank, work proceeds on the current branch (not suitable for parallel execution)

### Task Creation Questioning Flow

When creating a task, proactively gather the following through AskUserQuestion.
Do not skip fields — ask for each one unless the user has already explicitly provided it.

**Required questioning (in order):**

1. **Description**: Ask the user to describe the task in enough detail that an agent can execute
   without additional questions. If the description is vague (under ~50 tokens), ask follow-up
   questions: "What specifically needs to happen?", "What is the current state vs desired state?"

2. **Acceptance Criteria**: Ask "What are the completion conditions? How will we verify this task
   is done?" Guide toward machine-verifiable criteria:
   - Good: "command `npm test` passes", "file `src/auth.ts` exports `validateToken` function",
     "API returns 200 for `GET /health`"
   - Bad: "works correctly", "is implemented", "looks good"
   If criteria are vague, propose concrete alternatives and confirm.

3. **Execution Plan**: Ask "Do you have a plan for how to accomplish this, or would you like to
   build one together?" If the user provides a plan, confirm it. If not, propose a numbered
   plan based on the Description and Acceptance Criteria. Each step should specify:
   - What to do (action verb)
   - Which files/modules/areas to touch (if known)
   - Expected outcome of the step
   If the plan has >7 major steps or touches >5 distinct areas, suggest splitting into
   multiple smaller tasks.

4. **Context**: Ask "Is there any background information, constraints, or related context the
   executor should know?" (e.g., existing PRs, design docs, prior decisions)

## Human → Agent Re-assignment

When the user wants to change an Executor=human task to an agent:
- AskUserQuestion: "Execute '{task title}' with an agent? [cli / claude-desktop / keep human]"
- When cli or claude-desktop is selected:
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

If `sprintsDatabaseId` is available, also push sprint data to the view server:

```bash
# Silently skip if server is not running
curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && \
  curl -s -X POST http://localhost:3456/api/sprint-data \
    -H "Content-Type: application/json" -d '<sprints_json>' -o /dev/null 2>/dev/null || true
```

Sprints JSON format: `{ "sprints": [...], "currentSprintId": "<active_sprint_id_or_null>", "updatedAt": "<ISO>" }`

## My Tasks View

When the user asks "my tasks", "assigned to me", "show my tasks", or similar:

### Step 1: Provider Detection + Identity Resolve

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and determine `active_provider`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user`. Skip if already set.

### Step 2: Fetch My Tasks

Use the active provider SKILL.md's "Querying Tasks" section to fetch tasks filtered by Assignee = `current_user.id`. The provider determines the optimal query path.

### Step 3: Display by Status Group

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
- **human**: waiting for manual action

#### Blocked
For each task, show the blocking task titles (from `Blocked By` relation).

#### In Review
List tasks awaiting review.

#### Backlog
List titles only (collapsed to keep output concise).

#### Sprint Context
If `sprintsDatabaseId` is in config and an Active Sprint exists:
- Mark sprint tasks with `[Sprint]` prefix.
- Show sprint tasks first within each status group.

### Step 4: Next Actions

After displaying the task list, suggest next actions:

```
Next actions:
- Execute tasks: /executing-tasks
- Manage tasks (reassign, change status, etc.): /managing-tasks
- Delegate tasks: /delegating-tasks
```

## Language

Always communicate with the user in the language they are using.
Write all task content (Title, Description, Acceptance Criteria, Execution Plan, etc.)
in the user's language.
