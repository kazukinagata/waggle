# Task Creation Templates

## Pre-Creation Dedup Check

Before creating each task:
1. Generate `source_message_id` from the message unique ID (Slack: `channel_id:ts`)
2. Query the Tasks DB using the provider's "Querying Any Notion Database" flow with a filter for `Source Message ID` matching the current message's ID
3. If a matching task exists: skip the message and count it as `Skipped (already exists as task)`
4. If no match: include `Source Message ID` in the created task's fields

## Common Fields

| Field | Value |
|---|---|
| Title | `From @{sender}: {message summary (50 chars max)}` |
| Description | Full original message + append `Source: {tool_name} DM from @{sender} at {datetime}` |
| Tags | `["ingesting-messages"]` |
| Context | `Received via {tool_name} on {date}` |
| Issuer | `[current_user]` |

## Category-Specific Fields

### Category A (Hearing Needed)

1. Create the blocker task first:
   - Title: `[Hearing] Confirm with {requester_name}: {question summary}`
   - Status: `Ready`
   - Executor: If messaging MCP available (e.g. Slack tools) → `cowork` (agent can send follow-up messages). If no messaging MCP → `human` (requires manual contact).
   - Assignees: `[requester]` (Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve).
     If requester cannot be identified: `[current_user]` (fallback, not empty). Record "Original sender: {sender}" in Context.
   - Acceptance Criteria: `"Confirm with {requester_name} about {topic_summary}. Record response in Agent Output. Update Status to Done when confirmed."`
   - Execution Plan: `"1. Contact {requester_name} via {tool_name}\n2. Ask about: {question_summary}\n3. Record response in Agent Output\n4. Update Status to Done"`
2. Create the main task:
   - Status: `Blocked`
   - Blocked By: `[blocker_task_id]` *(relation field — set via `update-relations.sh` after task creation, not in `notion-create-pages` properties)*
   - Executor: Determine from message content — if the required action (after hearing) is clearly code/research/docs, infer executor (cli or cowork based on execution_environment). If unclear or requires human judgment → `human` (default, re-evaluated when unblocked).
   - Assignees: `[current_user]`
   - Acceptance Criteria: Derive from message content. Fallback: `"[DRAFT — update after hearing] Determine required action from {requester_name}'s response and complete it."`

### Category B (Self-Action)

- Status: `Ready`
- Executor: Determine from environment and context:
  - `execution_environment = "cowork"`: Default for AI-executed tasks is `cowork`
  - `execution_environment = "claude-desktop"`: Default for AI-executed tasks is `claude-desktop`
  - `execution_environment = "cli"`: Code work → `cli`, external integrations → `claude-desktop`
- Assignees: `[current_user]`
- Working Directory: Empty (user sets later)

### Category C (Delegate)

- Status: `Backlog`
- Assignees: Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve assignee
  - If assignee cannot be identified: `[current_user]` (fallback, not empty). Record "Expected assignee: {name or hint}" in Context
- Apply the field resets defined in `${CLAUDE_PLUGIN_ROOT}/skills/assigning-to-others/SKILL.md`.
