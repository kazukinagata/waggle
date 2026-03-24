---
name: delegating-tasks
description: >
  Delegates a task to another organization member by updating Assignees,
  resetting executor fields, and recording delegation history in Context.
  Triggers on: "delegate task", "assign to", "transfer task", "reassign",
  "タスク委任", "タスク移管", "割り当て変更"
user-invocable: true
---

# Waggle — Task Delegate

Delegates a task to another organization member. Changes Assignees to the recipient and appends delegation history to Context.

## Step 1: Provider Detection + Identity Resolve

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and determine `active_provider`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md`:
   - Resolve `current_user` (delegator identity).
   - Also resolve `org_members` (needed for recipient lookup).

## Step 2: Identify the Task

If the user did not specify a task clearly:
- Use AskUserQuestion to ask for the task title or ID.
- Search Tasks DB for matching tasks; if multiple match, present a short list and ask the user to confirm.

## Step 3: Identify the Recipient

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md`.
2. Run member lookup with the recipient name/email the user provided.
3. Handle results:
   - 0 matches → inform the user and ask for a different name or email.
   - 1 match → confirm: "Delegate to {recipient.name}?"
   - 2–5 matches → present the list and ask the user to select one.

## Step 3b: Content Quality Check

Before delegating, verify task content is sufficient for the recipient's agent to execute:
- If Acceptance Criteria is empty or under 20 characters: ask the user to provide
  completion conditions before delegating.
- If Description is empty: ask the user to provide a description before delegating.

These are non-blocking suggestions. Proceed with delegation if the user confirms.

## Step 4: Update the Task

Apply the following field updates (other fields remain unchanged).
**`Issuer` is preserved** (not modified) — it tracks the original task creator, not the current assignee.

| Field | Value | Reason |
|---|---|---|
| `Assignees` | `[recipient]` | Set the recipient as the responsible person |
| `Executor` | `human` | Recipient decides on their own (forced fixed) |
| `Working Directory` | Reset to empty | Recipient's filesystem is unknown |
| `Branch` | Reset to empty | Recipient's git environment is unknown |
| `Session Reference` | Reset to empty | Recipient's agent will record this |
| `Dispatched At` | Reset to empty | Recipient's agent will record this |
| `Requires Review` | Reset to unchecked | Recipient decides |
| `Context` | Append to existing text | Preserve delegation history |

Append format for the `Context` field:
```
Delegated from @{current_user.name} to @{recipient.name} on {YYYY-MM-DD}
```

(Optional) Confirm with the user and reset Status to `Backlog` (suggests re-triage).

## Step 5: Push to View Server

After updating the task, push fresh data to the view server as described in the active provider's SKILL.md (Pushing Data to View Server section).

## Step 6: Completion Message

Report:
```
Delegation complete: "{task title}" → @{recipient.name}
Delegation history has been appended to Context.
The recipient will see this task when they run managing-tasks (my tasks).
```

## Field Constraints for Delegated Tasks

**Do not set the following fields when assigning to another person** (the recipient decides):

| Field | Reason |
|---|---|
| `Executor` | Fixed to human (recipient will change if needed) |
| `Working Directory` | Recipient's filesystem info is unknown |
| `Branch` | Recipient's git environment is unknown |
| `Session Reference` | Recipient's agent will record this |
| `Dispatched At` | Recipient's agent will record this |
| `Requires Review` | Recipient decides |

## Language

Always respond in the user's language.
