---
name: planning-tasks
description: >
  Generates or refines Acceptance Criteria and Execution Plans for tasks.
  Single task or batch mode. Ensures tasks are executable at agent-autonomous quality.
  Uses multi-round brainstorming to extract quality information from users.
  Use this skill whenever the user wants to plan, prepare, refine, or improve
  a task before execution — including writing AC, execution plans, or making
  tasks ready for autonomous agents.
  Triggers on: "plan task", "refine task", "generate AC", "write execution plan",
  "plan all tasks", "auto-plan", "prepare task", "improve task", "batch plan".
user-invocable: true
---

# Waggle — Task Planning

You generate and refine Acceptance Criteria (AC) and Execution Plans for tasks. Your goal is to make tasks executable at agent-autonomous quality — detailed enough that an AI agent can complete them without additional questions.

## Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Target Selection

Three modes of operation:

### Single Task
User specifies a task by title, ID, or description. Search the Tasks DB and confirm the match.

### Batch Mode
User says "plan all Backlog tasks" or similar. Query by status filter.

### Pipeline Mode
Receives a list of task IDs from another skill (e.g., running-daily-tasks). Process each task in the list.

## Planning Flow

For each task, determine the planning path:

### Path A — [Hearing] Tasks (deterministic, no agent needed)

If the task title starts with `[Hearing]`:
- **AC**: `"Confirm with {person} about {topic_from_title}. Record response in Agent Output. Update Status to Done when confirmed."`
- **Execution Plan**: `"1. Contact {person} via messaging tool\n2. Ask about: {topic}\n3. Record response in Agent Output\n4. Update Status to Done"`
- Update the task immediately. No user confirmation needed (deterministic template).

### Path B — All Other Tasks (agent-delegated)

1. **Classify the task**:
   - Has Working Directory or Repository set → dispatch to `code-planning-agent`
   - Otherwise → dispatch to `knowledge-planning-agent`

2. **Check minimum input threshold**:
   - If Description has no nouns or meaningful context (e.g., just "fix bug" with no other info):
     escalate to user before spawning agent:
     "I need more context to plan this task. What specifically needs to happen?"
   - If user provides more context: update Description, then proceed
   - If user declines: skip this task

3. **Spawn the appropriate planning agent** via the Agent tool:
   - Provide: Title, Description, Context, AC (if partial), Working Directory, Repository
   - The agent follows the Multi-round Brainstorming Protocol (see below)
   - The agent returns: generated AC + Execution Plan as structured text

4. **Present agent output to user** for final confirmation:
   - Show the generated AC and Execution Plan
   - Options: `[Accept] [Edit] [Skip]`
   - If Accept: update the task via provider
   - If Edit: let user modify, then update
   - If Skip: leave task unchanged

5. **Validation gate**: Run the validation script on each updated task:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/scripts/validate-task-fields.sh \
     "Ready" /tmp/planned_task.json
   ```
   Report which tasks are now Ready-eligible.

### Batch Execution

When processing multiple tasks:
- Spawn agents in parallel (up to `maxConcurrentAgents`)
- Present all results together for bulk confirmation
- Summary: "Planned N tasks. M Ready-eligible. K need more context."

## Multi-round Brainstorming Protocol

This protocol is embedded in the planning agent prompts. The agent drives the conversation:

```
Round 1: Agent proposes an initial AC draft based on Title + Description + Context.
  → "Based on your task, I propose these completion criteria:
     1. {criterion 1}
     2. {criterion 2}
     3. {criterion 3}
     What would you add or change? You can also describe your own."

Round 2 (if user response lacks verifiable conditions):
  → Agent refines: "I understood X. Let me also suggest:
     - {additional criterion based on user input}
     - {edge case consideration}
     Anything else? What about error cases or edge conditions?"

Round 3 (continue if user is engaged):
  → Synthesize: "Here's the complete checklist:
     1. {final criterion 1}
     2. {final criterion 2}
     ...
     Anything missing?"
  → If user says "done" / "OK": finalize
  → If user adds more: incorporate and re-present

Fallback (user disengages — "that's enough", "just go with it", etc.):
  → Accept current state with [LOW CONFIDENCE] tag prepended
  → Move on to next task
```

**Key principle**: The agent PROPOSES first, then refines through dialogue. Never wait for the user to provide content from scratch — generate drafts proactively.

**Semantic triggers**: Round 2 fires when the user's response lacks verifiable conditions (no commands, file paths, metrics, or observable outcomes) — not based on character count.

## Execution Plan Generation

After AC is finalized, generate the Execution Plan:

- **Code tasks**: The code-planning-agent has already explored the codebase and generates steps with specific file paths, test commands, and module references.
- **Non-code tasks**: The knowledge-planning-agent generates a numbered plan using domain templates (see `references/knowledge-work-patterns.md`).
- Each step: action verb + target + expected outcome
- If >7 steps: suggest splitting the task into multiple tasks

## Summary Output

```
[Planning Complete]
Tasks processed: N
AC generated: X
Execution Plans generated: Y
Ready-eligible: Z (passed validation)
Skipped: K (insufficient context or user declined)
```
