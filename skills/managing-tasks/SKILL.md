---
name: managing-tasks
description: >
  Creates, updates, deletes, and queries tasks in the configured data source.
  Handles task creation with required confirmations, state transitions,
  "next task" recommendations, and personal task dashboard.
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

# Waggle — Task Management

You are managing tasks in the configured data source. Use the provider-specific tools for all data operations.

## Provider Detection (once per session)

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider`. Skip if already determined in this conversation.

After provider detection completes, you MUST read the provider SKILL.md (from detecting-provider's `provider_skill_path`) if you have not already done so. This file defines the Query Path Detection logic — do NOT query tasks using MCP tools directly without first determining the correct query path from the provider SKILL.md.

## Schema: Property Name → Notion Type

### Core Fields (15 required — verify existence at session start)

| Property | Type | Notes |
|---|---|---|
| Title | title | Task name |
| Description | rich_text | Orchestrator-written detail |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | select | Backlog / Ready / In Progress / In Review / Done / Blocked |
| Blocked By | relation | Self-relation (dependency). Empty or all blockers Done = actionable |
| Priority | select | Urgent / High / Medium / Low |
| Executor | select | cli / claude-desktop / cowork / human |
| Requires Review | checkbox | On → must pass In Review. Off → can go directly to Done |
| Execution Plan | rich_text | Orchestrator's plan written before dispatch. write-once |
| Working Directory | rich_text | Absolute path to the working directory |
| Session Reference | rich_text | Written after dispatch: tmux session name / Scheduled task ID |
| Dispatched At | date | Dispatch timestamp. Used for timeout detection |
| Agent Output | rich_text | Execution result |
| Error Message | rich_text | Written on failure only. Query with "Error Message is not empty" |
| Issuer | people | Who created/initiated this task. Auto-populated with current_user. Write-once. |

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

## State Transition Rules

Valid transitions:
- Backlog → Ready
- Ready → In Progress (when dispatched to executor)
- In Progress → In Review (when `Requires Review` is checked and work is done)
- In Progress → Done (when `Requires Review` is unchecked and work is done)
- In Progress → Blocked (when blocked by another task or error)
- In Review → Done (when review approved)
- In Review → In Progress (when changes requested)
- Any → Backlog (deprioritize)

**When `Requires Review` is Off**, skip In Review and transition directly to Done.
**When writing errors**, set Status to Blocked and write the error message in `Error Message` (not in Agent Output).

### Deterministic Validation (hard gate)

Before executing any status transition, run the validation script:

```bash
# Write the canonical task JSON to a temp file (see validating-fields SKILL.md for format)
echo '<canonical_json>' > /tmp/task_validate.json
bash ${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/scripts/validate-task-fields.sh \
  "<target_status>" /tmp/task_validate.json
```

1. Fetch the full task object and construct the canonical validation JSON (see `${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/SKILL.md` for the Construction Guide)
2. Run the script with the target status
3. Parse the JSON output:
   - If `valid: false`: present each error to the user and **block the transition**
   - If warnings exist: present them but allow the user to proceed
4. Only execute the status update after validation passes

**Never skip validation.** This is a deterministic check, not an LLM judgment call.

## "Next Task" Logic

When the user asks "what should I do next?" or "next task":

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

### Issuer (auto-populated, write-once)

Always set `Issuer = [current_user]` when creating a task. No confirmation needed.
Do not modify Issuer when delegating or reassigning — it tracks "who originated this task."

### Required Confirmations (no guessing or omitting)

Always confirm the following fields with AskUserQuestion unless the user has explicitly stated them.
Do NOT infer and commit to values from the task description.

| Field | Reason |
|---|---|
| Executor | Execution method varies entirely by executor type (cli / claude-desktop / cowork / human) |
| Priority | Urgency depends on the user's current context |
| Working Directory | Wrong path directly causes agent execution errors |

### How to Choose Executor

Never decide the Executor on your own.
Present options and recommended reasons to the user and let them decide.

| Executor | Best for |
|---|---|
| `cli` | Code implementation, research, documentation, script execution via Terminal CLI |
| `claude-desktop` | Tasks dispatched as Scheduled Tasks in Claude Desktop |
| `cowork` | Tasks dispatched as Scheduled Tasks in Cowork (cloud agent environment) |
| `human` | Tasks requiring human judgment, relationships, or direct interaction |

In AskUserQuestion, include a description with each option explaining why it is recommended.

**AI suitability info note**: When user switches Executor from human to AI (cli/claude-desktop/cowork), analyze the task Title + Description for task type indicators. If a non-code task is detected (design, marketing, meeting, phone call, etc.), add an informational note (not discouraging): "Note: this is a {category} task. AI can assist with research, drafting, and structured planning. Hands-on execution may still need human action." Proceed with the user's choice — do not block or ask "are you sure?"

### Environment-Specific Recommendations

- When `execution_environment = "cli"`: Recommend `cli` for AI-executed tasks.
  `claude-desktop` and `cowork` are also selectable, but inform the user that a separate environment is required.
- When `execution_environment = "claude-desktop"`: Recommend `claude-desktop` for AI-executed tasks.
  `cli` is also selectable, but inform the user that a separate Terminal CLI environment is required.
- When `execution_environment = "cowork"`: Recommend `cowork` for AI-executed tasks.
  `cli` is NOT available (no local terminal). `claude-desktop` is also selectable if the user has a Desktop environment.

### Branch (git worktree support)

Not applicable in cowork (no persistent local filesystem).

For tasks with Executor=cli where the target is a git repository:
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

**Multi-round questioning**: For AC and Execution Plan, if the user's response lacks verifiable conditions (no commands, file paths, metrics, or observable outcomes), propose 3 concrete options and brainstorm together. If the user disengages, accept with `[LOW CONFIDENCE]` tag.

**Auto-planning shortcut**: If the user says "auto", "自動で", or "generate" for AC or Execution Plan, propose AC and Execution Plan based on the Description. If Description is too vague (no nouns, no context), ask the user to elaborate first.

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
- **cowork**: ready for Cowork Scheduled Task
- **human**: waiting for manual action

#### Blocked
For each task, show the blocking task titles (from `Blocked By` relation).

#### In Review
List tasks awaiting review.

#### Backlog
List titles only (collapsed to keep output concise).

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
