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
| Description | Build the description in order: (1) If `thread_context` is available, include thread context followed by a `---` separator. (2) Include the full original message text. (3) If `attachment_info` is available and has images, include an `[Attachments]` section (see "Attachment Info in Descriptions" below). (4) Append `Source: {tool_name} DM from @{sender} at {datetime}` at the end. Steps 3 and 4 apply regardless of whether thread context is present. |
| Tags | `["ingesting-messages"]` |
| Context | `Received via {tool_name} on {date}` |
| Issuer | `[current_user]` |

### Thread Context in Descriptions

When a message has `thread_context`, structure the Description field as:

```
[Thread Context — {N} messages in #{channel_name}]
@{parent_author}: {parent_message_text}
@{reply_author}: {reply_text}
... ({K} earlier replies omitted)
@{recent_reply_author}: {recent_reply_text}
---
@{sender}: {original_message_text}

Source: {tool_name} DM from @{sender} at {datetime}
```

This gives the task executor full conversational context without needing to open the messaging tool.

### Attachment Info in Descriptions

When a message has `attachment_info` with images, include an `[Attachments]` section in the Description field after the message text and before the `Source:` line.

**When images were successfully read:**

```
[Attachments — {N} image(s)]
- {filename}: {AI-generated description}
```

**When images could not be read:**

```
[Attachments — {N} image(s), could not be read automatically]
- {filename}: (image not readable — view original message)
- Message link: {message_permalink}
```

**Mixed (some read, some not — includes skipped images from global cap):**

```
[Attachments — {N} image(s)]
- {filename}: {AI-generated description}
- {filename}: (image not readable — view original message)
- {filename}: (image skipped — global processing cap reached)
- Message link: {message_permalink}
```

**Full Description example with thread context and attachments:**

```
[Thread Context — 3 messages in #engineering]
@alice: Can someone look at the checkout page? It's broken for mobile users.
@bob: I think it's the CSS grid layout.
---
@alice: Here's what I'm seeing on my phone

[Attachments — 1 image(s)]
- screenshot_mobile.png: Mobile view of checkout page showing overlapping elements in the payment form section. The "Submit" button is hidden behind the address fields. Viewport appears to be approximately 375px wide.

Source: slack DM from @alice at 2026-04-10 09:15
```

## Category-Specific Fields

### Category A (Hearing Needed)

1. Create the blocker task first:
   - Title: `[Hearing] Confirm with {requester_name}: {question summary}`
   - Status: `Ready`
   - Executor: If messaging MCP available (e.g. Slack tools) → `cowork` (agent can send follow-up messages). If no messaging MCP → `human` (requires manual contact).
   - Assignee: `[requester]` (Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve).
     If requester cannot be identified: `[current_user]` (fallback, not empty). Record "Original sender: {sender}" in Context.
   - Acceptance Criteria: `"Confirm with {requester_name} about {topic_summary}. Record response in Agent Output. Update Status to Done when confirmed."`
   - Execution Plan: `"1. Contact {requester_name} via {tool_name}\n2. Ask about: {question_summary}\n3. Record response in Agent Output\n4. Update Status to Done"`
2. Create the main task:
   - Status: `Blocked`
   - Blocked By: `[blocker_task_id]` *(relation field — set via `update-relations.sh` after task creation, not in `notion-create-pages` properties)*
   - Executor: Determine from message content — if the required action (after hearing) is clearly code/research/docs, infer executor (cli or cowork based on execution_environment). If unclear or requires human judgment → `human` (default, re-evaluated when unblocked).
   - Assignee: `[current_user]`
   - Acceptance Criteria: Derive from message content. Fallback: `"[DRAFT — update after hearing] Determine required action from {requester_name}'s response and complete it."`

### Category B (Self-Action)

- Status: `Ready`
- Executor: Determine from environment and context:
  - `execution_environment = "cowork"`: Default for AI-executed tasks is `cowork`
  - `execution_environment = "claude-desktop"`: Default for AI-executed tasks is `claude-desktop`
  - `execution_environment = "cli"`: Code work → `cli`, external integrations → `claude-desktop`
- Assignee: `[current_user]`
- Working Directory: Empty (user sets later)

### Category C (Delegate)

- Status: `Backlog`
- Assignee: Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve assignee
  - If assignee cannot be identified: `[current_user]` (fallback, not empty). Record "Expected assignee: {name or hint}" in Context
- Apply the field resets defined in `${CLAUDE_PLUGIN_ROOT}/skills/assigning-to-others/SKILL.md`.
