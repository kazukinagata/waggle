---
name: delegating-tasks
description: >
  Delegates a task to another organization member by updating Assignee,
  resetting executor fields, and recording delegation history in Context.
  Use this skill whenever the user wants to hand off, transfer, reassign,
  or give a task to someone else — even if they don't say "delegate" explicitly.
  Triggers on: "delegate task", "assign to", "transfer task", "reassign",
  "hand off", "give to", "pass to another person".
user-invocable: true
---

# Waggle — Task Delegate

Delegates a task to another organization member. Changes Assignee to the recipient and appends delegation history to Context.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server pushes. Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the outcome (e.g., a non-PASS quality verdict and
  the gaps behind it — it explains why a task lands at a different status than expected)
- the final result summary

## Step 1: Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
Skip if `active_provider` and `current_user` are already set in this conversation.
Also invoke the `looking-up-members` skill to resolve `org_members` (needed for recipient lookup).

## Step 2: Identify the Task

If the user did not specify a task clearly:
- Use AskUserQuestion to ask for the task title or ID.
- Search Tasks DB for matching tasks; if multiple match, present a short list and ask the user to confirm.

## Step 3: Identify the Recipient

1. Invoke the `looking-up-members` skill.
2. Run member lookup with the recipient name/email the user provided.
3. Handle results:
   - 0 matches → inform the user and ask for a different name or email.
   - 1 match → confirm: "Delegate to {recipient.name}?"
   - 2–5 matches → present the list and ask the user to select one.
   - Team name match (lookup returns `teamMatch: true`): inform "'{query}' is a team name. Assignee must be exactly 1 person. Which member of {teamName} should this be delegated to?" and present the team's member list for selection.

## Step 3b: Content Quality Check (v2.8.0+: live cache-aware Reviewer)

Delegation is a low-frequency, high-impact action — handing work to someone else. v2.8.0 strengthens this step to catch tasks that bypassed the quality gates (e.g., Notion UI direct edits) before they reach the recipient.

Invoke the `assigning-to-others` skill at the field-reset point in Step 4. That skill now performs a **live, cache-aware** Reviewer check via `reviewing-quality`:

- Cache hit + PASS → delegation proceeds silently (99% of the case, no LLM wait).
- Cache hit + NEEDS_REFINEMENT / REJECT → surface gaps; ask `[Refine via /planning-tasks] [Delegate anyway]`.
- Cache miss → **live Reviewer invocation** (~10–20s). delegation is rare enough that this latency is acceptable. After the Reviewer returns, branch on its verdict the same way.

Legacy non-LLM checks (kept as fast pre-checks):
- If Acceptance Criteria is empty or under 20 characters: still prompt the user.
- If Description is empty: still prompt the user.

These remain non-blocking suggestions; the user can override with `[Delegate anyway]`.

## Step 4: Update the Task

Apply the following field updates (other fields remain unchanged).
**`Issuer` is preserved** (not modified) — it tracks the original task creator, not the current assignee. Under v2.8.1+ this is enforced at the provider boundary (Notion's `created_by` column is read-only; SQLite/Turso Update Task templates do not include `issuer`). Skills do not need to take any action to preserve Issuer; just refrain from passing it in update payloads.

1. Set `Assignee` to `[recipient]`.
2. Invoke the `assigning-to-others` skill and apply the field resets it defines (this clears `Acknowledged At` among other fields).
3. **Self-delegation exception**: If `recipient.id == current_user.id`, set `Acknowledged At` to the current ISO 8601 timestamp (no acknowledgment needed for self-assigned tasks).
4. Append delegation history to `Context` (see format below).

Append format for the `Context` field:
```
Delegated from @{current_user.name} to @{recipient.name} on {YYYY-MM-DD}
```

(Optional) Confirm with the user and reset Status to `Backlog` (suggests re-triage).

## Step 5: Push to View Server

After updating the task, push fresh data to the view server as described in the active provider's SKILL.md (Pushing Data to View Server section).

## Step 5b: Opt-in Slack Notification

After pushing to the view server, offer to notify the recipient via Slack DM.

**Skip this step if**: the recipient is the current user (self-delegation).

1. Use AskUserQuestion: "Send a Slack DM to @{recipient.name} about this delegation? [Yes / No]"
2. If **No** (or equivalent): skip to Step 6.
3. If **Yes**:
   a. Check that Slack MCP tools are available (`slack_send_message`, `slack_search_users`).
      - If not available: inform "Slack MCP is not configured. Skipping notification." and proceed to Step 6.
   b. Resolve the recipient's Slack user ID using `slack_search_users` with the recipient's name or email.
      - If no match found: inform "Could not find {recipient.name} on Slack. Skipping notification." and proceed to Step 6.
   c. Send a DM via `slack_send_message`:
      ```
      You've been assigned a task: "{task title}"
      Priority: {priority}
      From: @{current_user.name}
      ```
   d. Report: "Slack notification sent to @{recipient.name}."

## Step 6: Completion Message

Report:
```
Delegation complete: "{task title}" → @{recipient.name}
Delegation history has been appended to Context.
The recipient will see this task when they run managing-tasks (my tasks).
```

## Field Constraints for Delegated Tasks

Invoke the `assigning-to-others` skill for the canonical field reset rules applied when assigning to another person.
