# Task Creation Flow

## Assignees and Identity Resolution

**Assignees is always exactly 1 person** (skill-level rule). If multiple people are needed, suggest splitting the task.

**When the task is for the user themselves:**
- When the user explicitly says "my" or "for me":
  Automatically set `current_user` in `Assignees` (no confirmation needed).

**When assigning to another member:**
- When the user specifies another member's name:
  1. Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve the member ID (this will also resolve `org_members` if not yet set).
  3. If multiple candidates match, confirm with AskUserQuestion.
  4. Only ask via AskUserQuestion if the member cannot be found.
  5. Apply the field resets defined in `${CLAUDE_PLUGIN_ROOT}/skills/assigning-to-others/SKILL.md`.

## Issuer (auto-populated, write-once)

Always set `Issuer = [current_user]` when creating a task. No confirmation needed.
Do not modify Issuer when delegating or reassigning — it tracks "who originated this task."

## Required Confirmations (no guessing or omitting)

Always confirm the following fields with AskUserQuestion unless the user has explicitly stated them.
Do NOT infer and commit to values from the task description.

| Field | Reason |
|---|---|
| Executor | Execution method varies entirely by executor type (cli / claude-desktop / cowork / human) |
| Priority | Urgency depends on the user's current context |
| Working Directory | Wrong path directly causes agent execution errors |

## How to Choose Executor

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

## Environment-Specific Recommendations

- When `execution_environment = "cli"`: Recommend `cli` for AI-executed tasks.
  `claude-desktop` and `cowork` are also selectable, but inform the user that a separate environment is required.
- When `execution_environment = "claude-desktop"`: Recommend `claude-desktop` for AI-executed tasks.
  `cli` is also selectable, but inform the user that a separate Terminal CLI environment is required.
- When `execution_environment = "cowork"`: Recommend `cowork` for AI-executed tasks.
  `cli` is NOT available (no local terminal). `claude-desktop` is also selectable if the user has a Desktop environment.

## Branch (git worktree support)

Not applicable in cowork (no persistent local filesystem).

For tasks with Executor=cli where the target is a git repository:
- Suggest setting the Branch field (not mandatory)
- Default candidate: `feature/<task-title-slug>`
- If set, executing-tasks can create an isolated environment via `git worktree add`
- If left blank, work proceeds on the current branch (not suitable for parallel execution)

## Task Creation Questioning Flow

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

**Auto-planning shortcut**: If the user says "auto" or "generate" for AC or Execution Plan, propose AC and Execution Plan based on the Description. If Description is too vague (no nouns, no context), ask the user to elaborate first.

## Pre-Creation Checklist (hard gate)

Before calling the provider's create API, verify ALL of the following have been addressed:

| # | Field | Confirmed? |
|---|---|---|
| 1 | Description (≥50 tokens, specific enough for agent execution) | |
| 2 | Acceptance Criteria (verifiable conditions) | |
| 3 | Execution Plan (numbered steps with actions and expected outcomes) | |
| 4 | Context (asked — may be empty if user says "none") | |

**Do NOT create the task until all 4 rows are confirmed.** If any field was skipped or not yet asked, go back and ask before proceeding.

## Status Auto-Determination at Creation

Do NOT hardcode Status to Backlog. Determine it dynamically:

1. After gathering all fields, construct the canonical validation JSON from the gathered values
2. Run `validate-task-fields.sh "Ready"` against the gathered fields
3. If `valid: true` → create with **Status = Ready**
4. If `valid: false` → create with **Status = Backlog**, inform the user which fields need refinement before the task can be promoted to Ready
