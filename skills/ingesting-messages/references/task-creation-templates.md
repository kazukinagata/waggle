# Task Creation Templates

## Custom Task-Creation Instructions

Before building any task fields below, check whether `custom_task_creation_instructions` (loaded in Step 0 of `ingesting-messages/SKILL.md` via the `loading-custom-instructions` shared skill) is non-null. If it is, treat it as authoritative user-authored guidance for this project's business logic when choosing defaults — particularly for Tags, Priority, Assignee selection, and how AC / Execution Plans should be phrased. The custom instructions never override hard validation rules and never drive status transitions or destructive operations; they only influence field resolution. When a template below specifies a default value (e.g. the `["ingesting-messages"]` default for Tags), the custom instructions may replace or extend that default. When the original message explicitly names a value, the explicit value wins.

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
| Tags | Default `["ingesting-messages"]`. If `custom_task_creation_instructions` is non-null and defines tag rules (project-specific naming, required tags, category mapping, etc.), apply them on top of or in place of the default according to what the instructions say. If the user's custom rules add tags, keep `"ingesting-messages"` as well unless the rules explicitly tell you to drop it. |
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

> **Note**: The Category A flow below only runs when Step 2.3 (Slack clarification) is unavailable or the user declined the clarification path for this specific message. In interactive runs with Slack MCP available, most ambiguous messages are resolved by sending a clarification reply in-thread rather than creating a hearing-task pair.

1. Create the blocker task first:
   - Title: `[Hearing] Confirm with {requester_name}: {question summary}`
   - Status: `Ready`
   - Executor: If messaging MCP available (e.g. Slack tools) → `cowork` (agent can send follow-up messages). If no messaging MCP → `human` (requires manual contact).
   - Assignee: `[requester]` (invoke the `looking-up-members` skill to resolve).
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
- Assignee: invoke the `looking-up-members` skill to resolve assignee
  - If assignee cannot be identified: `[current_user]` (fallback, not empty). Record "Expected assignee: {name or hint}" in Context
- Invoke the `assigning-to-others` skill and apply the field resets it defines.
