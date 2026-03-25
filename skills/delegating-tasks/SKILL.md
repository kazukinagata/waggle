---
name: delegating-tasks
description: >
  Delegates a task to another organization member by updating Assignees,
  resetting executor fields, and recording delegation history in Context.
  Use this skill whenever the user wants to hand off, transfer, reassign,
  or give a task to someone else — even if they don't say "delegate" explicitly.
  Triggers on: "delegate task", "assign to", "transfer task", "reassign",
  "hand off", "give to", "pass to another person".
user-invocable: true
---

# Waggle — Task Delegate

Delegates a task to another organization member. Changes Assignees to the recipient and appends delegation history to Context.

## Step 1: Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.
Also resolve `org_members` via `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` (needed for recipient lookup).

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

1. Set `Assignees` to `[recipient]`.
2. Apply the field resets defined in `${CLAUDE_PLUGIN_ROOT}/skills/assigning-to-others/SKILL.md`.
3. Append delegation history to `Context` (see format below).

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

See `${CLAUDE_PLUGIN_ROOT}/skills/assigning-to-others/SKILL.md` for the canonical field reset rules applied when assigning to another person.
